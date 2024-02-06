--liquibase formatted sql

--changeset KarinaMasihHudson:c208dd59-4d1c-40a2-89e3-ea963a0e6755 stripComments:false runOnChange:true

/*=============================================
       Author : Karina Masih-Hudson
  Create Date : 2023-10-05
  Description : Look up residuals for accounts under an MA
 SSIS Package : SSIS_Victra > ResidualByMA.dtsx
          Job : DataTeam_Processing_VictraAccountResiduals
        Usage : EXEC [Report].[P_Report_ResidualPayments_MALookup] 155536, NULL, NULL
  KMH20240124 : Changed activation requirement for residual payments in final join; may be cases where no activation
                exists in our system but residual payment includes the ESN/SIM
				ROW_NUMBER added to #Activations for cases of ESN or SIM being tied on file but being activated separately with
                different mapping in case Victra wants us to only report one instead of "duplicating" the row with
                amount but two different activation orders
 =============================================*/

ALTER PROCEDURE [Report].[P_Report_ResidualPayments_MALookup]
    (@Account_ID INT, @StartDate DATE, @EndDate DATE)
AS

BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        ---------testing
        --DECLARE @Account_ID INT = 155536
        --      , @StartDate DATE = NULL --'2023-05-01'
        --      , @EndDate DATE =  NULL;  --'2023-05-02'

        IF
            NOT EXISTS (
                SELECT Account_ID
                FROM CellDay_Prod.dbo.Account
                WHERE
                    Account_ID = @Account_ID
                    AND AccountType_ID IN (5, 6, 8)
            )
            BEGIN
                SELECT 'This report is highly restricted! If you need access, please see your T-Cetra
                representative.' AS [Error Message];
                RETURN;
            END;

        -------------------------------------------------------------------------------------------------------------
        DECLARE @dback SMALLINT = CASE WHEN DATENAME(WEEKDAY, GETDATE()) = 'Monday' THEN -3 ELSE -1 END;

        IF @StartDate IS NULL
            SET @StartDate = DATEADD(DAY, @dback, CONVERT(DATE, GETDATE()));

        IF @EndDate IS NULL
            SET @EndDate = CONVERT(DATETIME, CONVERT(DATE, GETDATE()));

        IF (@StartDate > @EndDate)
            RAISERROR ('"Start Date:" can not be later than the "End Date:", please re-enter your dates!', 11, 1);

        --------------------------------------------------------------------------------------------------------------

        CREATE TABLE #ListOfAccounts (AccountID INT);

        IF (
            SELECT a.AccountType_ID
            FROM dbo.Account AS a
            WHERE a.Account_ID = @Account_ID
        ) IN (5, 6, 8)
            BEGIN
                INSERT INTO #ListOfAccounts
                EXEC [Account].[P_Account_GetAccountList]
                    @AccountID = @Account_ID             -- int
                    , @UserID = 1                          -- int
                    , @AccountTypeID = '2,11'              -- varchar(50)
                    , @AccountStatusID = '0,1,2,3,4,5,6,7' -- varchar(50)
                    , @Simplified = 1;                     -- bit
            END;

        INSERT INTO #ListOfAccounts (AccountID)
        VALUES
        (@Account_ID);


        DROP TABLE IF EXISTS #DataStuff;

        SELECT
            dcd.DealerCommissionDetailID
            , dcd.RTR_TXN_REFERENCE1
            , dcd.ESN
            , dcd.SIM
            , CONVERT(DATE, dcd.TRANSACTION_DATE) AS Transaction_Date
            , CONVERT(INT, dcd.TSP_ID) AS TSP_ID
            , CONVERT(DECIMAL(9, 3), dcd.COMMISSION_AMOUNT) AS Commission_Amount
            , CONVERT(DATE, dcd.Create_Date) AS Create_Date
        INTO #DataStuff
        FROM CellDay_Prod.Tracfone.tblDealerCommissionDetail AS dcd
        WHERE
            dcd.Create_Date >= @StartDate --DATEADD(DAY, -10, CONVERT(DATE, GETDATE()))
            AND dcd.Create_Date < @EndDate --CONVERT(DATE, GETDATE())
            AND dcd.COMMISSION_TYPE LIKE 'DEALER RESIDUAL'
            AND EXISTS (
                SELECT 1
                FROM #ListOfAccounts AS la
                WHERE CONVERT(VARCHAR(15), la.AccountID) = dcd.TSP_ID
            );


        DROP TABLE IF EXISTS #ResidualOrder

        ; WITH cteResiduals AS (
            SELECT
                ds.TSP_ID
                , ds.Create_Date
                , SUM(ds.Commission_Amount) AS Residual_Amount_Invoiced
            FROM #DataStuff AS ds
            GROUP BY
                ds.TSP_ID
                , ds.Create_Date
        )
        SELECT
            c.TSP_ID
            , c.Create_Date
            , c.Residual_Amount_Invoiced
            , od.Order_No AS [Residual_OrderNumber]
            , od.OrderTotal AS [Commission_Amount_Total]
            , od.DateFilled AS [Residual_DateFilled]
            , od.OrderTotal
            , od.DateOrdered
        INTO #ResidualOrder
        FROM cteResiduals AS c
        JOIN dbo.Order_No AS od
            ON
                od.Account_ID = c.TSP_ID
                AND c.Create_Date = CONVERT(DATE, od.DateOrdered)
                AND (c.Residual_Amount_Invoiced * -1) = od.OrderTotal
        WHERE
            od.OrderType_ID IN (28, 38)
            AND od.Void = 0;


        --SELECT * FROM #ResidualOrder

        DROP TABLE IF EXISTS #ActivationOrder;

        CREATE TABLE #ActivationOrder
        (
            DealerCommissionDetailID INT, Transaction_Date DATE, TSP_ID INT, ESN VARCHAR(40), SIM VARCHAR(40)
            , Commission_Amount DECIMAL(9, 3), Create_Date DATETIME, Activation_Order_No INT, RowNum INT
        );

        INSERT INTO #ActivationOrder
        SELECT DISTINCT
            ds.DealerCommissionDetailID
            , ds.Transaction_Date
            , ds.TSP_ID
            , esn.AddonsValue AS ESN
            , sim.AddonsValue AS [SIM]
            , ds.Commission_Amount
            , ds.Create_Date
            , od.Order_No
            , ROW_NUMBER() OVER (PARTITION BY ds.DealerCommissionDetailID ORDER BY ds.DealerCommissionDetailID)
                AS RowNum
        FROM #DataStuff AS ds
        JOIN dbo.tblOrderItemAddons AS esn
            ON ds.ESN = esn.AddonsValue
        JOIN dbo.tblAddonFamily AS aof
            ON
                aof.AddonID = esn.AddonsID
                AND aof.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
        JOIN dbo.tblOrderItemAddons AS sim
            ON ds.SIM = sim.AddonsValue
        JOIN dbo.tblAddonFamily AS aof2
            ON
                aof2.AddonID = sim.AddonsID
                AND aof2.AddonTypeName IN ('SimType', 'SimBYOPType')
        JOIN dbo.Orders AS o
            ON
                o.ID = esn.OrderID
                AND ISNULL(o.ParentItemID, 0) IN (0, 1)
        JOIN dbo.Order_No AS od
            ON od.Order_No = o.Order_No
        --AND CONVERT(DATE,od.DateOrdered) <= ds.TRANSACTION_DATE
        WHERE
            od.OrderType_ID IN (1, 9, 22, 23)
            AND od.Void = 0
        ORDER BY ds.DealerCommissionDetailID



        ; WITH cteFinal AS (
            SELECT DISTINCT
                ds.DealerCommissionDetailID,
                ds.Transaction_Date
                , ds.TSP_ID
                , ds.SIM AS SIM
                --, IIF(ISNULL(ao.SIM,'') LIKE '', ds.sim, ao.sim) AS SIM
                , ds.Commission_Amount
                , ro.Residual_OrderNumber
                , ro.Commission_Amount_Total
                , ro.Residual_DateFilled
                , ao.Activation_Order_No
                , IIF(ISNULL(ao.esn, '') LIKE '', ds.ESN, ao.esn) AS ESN
            FROM #DataStuff AS ds
            LEFT JOIN #ResidualOrder AS ro
                ON
                    ro.TSP_ID = ds.TSP_ID
                    AND ds.Create_Date = ro.Create_Date
            LEFT JOIN #ActivationOrder AS ao
                ON
                    ao.TSP_ID = ds.TSP_ID
                    AND ao.ESN = ds.ESN
        --AND ao.RowNum = 1
        )
        SELECT
            cteFinal.Transaction_Date
            , cteFinal.TSP_ID
            , cteFinal.ESN
            , cteFinal.SIM
            , cteFinal.Commission_Amount
            , cteFinal.Residual_OrderNumber
            , cteFinal.Commission_Amount_Total
            , cteFinal.Residual_DateFilled
            , cteFinal.Activation_Order_No
        FROM cteFinal
        ORDER BY cteFinal.Residual_OrderNumber, cteFinal.ESN



    --DROP TABLE IF EXISTS #ListOfAccounts
    --DROP TABLE IF EXISTS #DataStuff
    --DROP TABLE IF EXISTS #ResidualOrder
    --DROP TABLE IF EXISTS #ActivationOrder

    END TRY

    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ErrorNumber
            , ERROR_MESSAGE() AS ErrorMessage;
    END CATCH

END;

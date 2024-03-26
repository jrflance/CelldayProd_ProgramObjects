--liquibase formatted sql

--changeset KarinaMasihHudson:50bb507468f1460eb7e04b0cb282fe60 stripComments:false runOnChange:true splitStatements:false
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
  KMH20240304 : Added BillItemNumber
 =============================================*/

ALTER PROCEDURE [Report].[P_Report_ResidualPayments_MALookup]
    (@Account_ID INT, @StartDate DATE, @EndDate DATE)
AS

BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        ----testing
        --DECLARE @Account_ID INT = 157814
        --, @StartDate DATETIME = '2023-03-01'
        --, @EndDate DATETIME = '2024-03-30'

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
        DROP TABLE IF EXISTS #ListOfAccounts;
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
            , dcd.RTR_TXN_REFERENCE1 AS [BillItemNumber] --KMH20240304
            , CONVERT(DATE, dcd.TRANSACTION_DATE) AS Transaction_Date
            , CONVERT(INT, dcd.TSP_ID) AS TSP_ID
            , CONVERT(DECIMAL(9, 3), dcd.COMMISSION_AMOUNT) AS Commission_Amount
            , CONVERT(DATE, dcd.Create_Date) AS Create_Date
        INTO #DataStuff
        FROM CellDay_Prod.Tracfone.tblDealerCommissionDetail AS dcd
        WHERE
            dcd.Create_Date >= @StartDate
            AND dcd.Create_Date < @EndDate
            AND dcd.COMMISSION_TYPE LIKE 'DEALER RESIDUAL'
            AND EXISTS (
                SELECT 1
                FROM #ListOfAccounts AS la
                WHERE CONVERT(VARCHAR(15), la.AccountID) = dcd.TSP_ID
            )

        -- For historical as dcd only keeps few weeks of data
        --SET IDENTITY_INSERT #DataStuff ON
        -- INSERT INTO #DataStuff
        -- (
        -- DealerCommissionDetailID, RTR_TXN_REFERENCE1, ESN, SIM, BillItemNumber
        -- , Transaction_Date, TSP_ID, Commission_Amount, Create_Date
        -- )
        -- SELECT
        -- dcd.DealerCommissionDetailID
        -- , dcd.RTR_TXN_REFERENCE1
        -- , dcd.ESN
        -- , dcd.SIM
        -- , dcd.RTR_TXN_REFERENCE1 AS [BillItemNumber] --KMH20240304
        -- , CONVERT(DATE, dcd.TRANSACTION_DATE) AS Transaction_Date
        -- , CONVERT(INT, dcd.TSP_ID) AS TSP_ID
        -- , CONVERT(DECIMAL(9, 3), dcd.COMMISSION_AMOUNT) AS Commission_Amount
        -- , CONVERT(DATE, dcd.Create_Date) AS Create_Date
        -- FROM CellDay_History.Tracfone.tblDealerCommissionDetail AS dcd
        -- WHERE
        -- dcd.Create_Date >= @StartDate
        -- AND dcd.Create_Date < @EndDate
        -- AND dcd.COMMISSION_TYPE LIKE 'DEALER RESIDUAL'
        -- AND EXISTS (
        -- SELECT 1
        -- FROM #ListOfAccounts AS la
        -- WHERE CONVERT(VARCHAR(15), la.AccountID) = dcd.TSP_ID
        -- )
        -- AND NOT EXISTS (SELECT 1 FROM #DataStuff AS d WHERE d.DealerCommissionDetailID = dcd.DealerCommissionDetailID)
        -- SET IDENTITY_INSERT #DataStuff OFF


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
            AND od.Process = 1 AND od.Filled = 1 AND od.Void = 0;

        DROP TABLE IF EXISTS #ActivationOrder;

        CREATE TABLE #ActivationOrder
        (
            DealerCommissionDetailID INT, Transaction_Date DATE, TSP_ID INT, ActivationAccountID INT, ESN VARCHAR(40), SIM VARCHAR(40)
            , Commission_Amount DECIMAL(9, 3), Create_Date DATETIME, Activation_Order_No INT, BillItemNumber VARCHAR(15), RowNum INT
        );

        INSERT INTO #ActivationOrder
        SELECT DISTINCT
            ds.DealerCommissionDetailID
            , ds.Transaction_Date
            , ds.TSP_ID
            , od.account_ID AS [ActivationAccountID]
            , esn.AddonsValue AS ESN
            , sim.AddonsValue AS [SIM]
            , ds.Commission_Amount
            , ds.Create_Date
            , od.Order_No
            , ds.BillItemNumber
            , ROW_NUMBER() OVER (PARTITION BY ds.DealerCommissionDetailID ORDER BY ds.DealerCommissionDetailID)
                AS RowNum
        FROM #DataStuff AS ds
        JOIN dbo.tblOrderItemAddons AS bin
            ON
                ds.BillItemNumber = bin.AddonsValue
                AND bin.AddonsID = 196
        JOIN dbo.Orders AS o
            ON
                o.ID = bin.OrderID
                AND ISNULL(o.ParentItemID, 0) IN (0, 1)
        JOIN dbo.Order_No AS od
            ON od.Order_No = o.Order_No
        LEFT JOIN dbo.tblOrderItemAddons AS esn
            ON o.ID = esn.OrderID
        JOIN dbo.tblAddonFamily AS aof
            ON
                aof.AddonID = esn.AddonsID
                AND aof.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
        LEFT JOIN dbo.tblOrderItemAddons AS sim
            ON sim.OrderID = o.ID
        JOIN dbo.tblAddonFamily AS aof2
            ON
                aof2.AddonID = sim.AddonsID
                AND aof2.AddonTypeName IN ('SimType', 'SimBYOPType', 'ESimType')
        --AND CONVERT(DATE,od.DateOrdered) <= ds.TRANSACTION_DATE
        WHERE
            od.OrderType_ID IN (1, 9, 22, 23)
            AND od.Process = 1 AND od.Filled = 1 AND od.Void = 0
        ORDER BY ds.DealerCommissionDetailID

        --historical
        --; WITH cteResiduals AS (
        --SELECT
        --ds.TSP_ID
        --, ds.Create_Date
        --, SUM(ds.Commission_Amount) AS Residual_Amount_Invoiced
        --FROM #DataStuff AS ds
        --GROUP BY
        --ds.TSP_ID
        --, ds.Create_Date
        --)
        --INSERT INTO #ResidualOrder
        --SELECT
        --c.TSP_ID
        --, c.Create_Date
        --, c.Residual_Amount_Invoiced
        --, od.Order_No AS [Residual_OrderNumber]
        --, od.OrderTotal AS [Commission_Amount_Total]
        --, od.DateFilled AS [Residual_DateFilled]
        --, od.OrderTotal
        --, od.DateOrdered
        --FROM cteResiduals AS c
        --JOIN CellDay_History.dbo.Order_No AS od
        --ON
        --od.Account_ID = c.TSP_ID
        --AND c.Create_Date = CONVERT(DATE, od.DateOrdered)
        --AND (c.Residual_Amount_Invoiced * -1) = od.OrderTotal
        --WHERE
        --od.OrderType_ID IN (28, 38)
        --AND od.Process = 1 AND od.Filled = 1 AND od.Void = 0;


        --INSERT INTO #ActivationOrder
        --SELECT DISTINCT
        --ds.DealerCommissionDetailID
        --, ds.Transaction_Date
        --, ds.TSP_ID
        --, od.account_ID [ActivationAccountID]
        --, esn.AddonsValue AS ESN
        --, sim.AddonsValue AS [SIM]
        --, ds.Commission_Amount
        --, ds.Create_Date
        --, od.Order_No
        --,ds.BillItemNumber
        --, ROW_NUMBER() OVER (PARTITION BY ds.DealerCommissionDetailID ORDER BY ds.DealerCommissionDetailID)
        --AS RowNum
        --FROM #DataStuff AS ds
        --JOIN dbo.tblOrderItemAddons bin
        --	ON ds.BillItemNumber = bin.AddonsValue AND bin.AddonsID = 196
        --JOIN CellDay_History.dbo.Orders AS o
        --ON
        --o.ID = bin.OrderID
        --AND ISNULL(o.ParentItemID, 0) IN (0, 1)
        --JOIN CellDay_History.dbo.Order_No AS od
        --ON od.Order_No = o.Order_No
        --LEFT JOIN dbo.tblOrderItemAddons AS esn
        --ON o.ID = esn.OrderID
        --JOIN dbo.tblAddonFamily AS aof
        -- ON
        --aof.AddonID = esn.AddonsID
        --AND aof.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
        --LEFT JOIN dbo.tblOrderItemAddons AS sim
        --ON o.ID = sim.OrderID
        --JOIN dbo.tblAddonFamily AS aof2
        --ON
        --aof2.AddonID = sim.AddonsID
        --AND aof2.AddonTypeName IN ('SimType', 'SimBYOPType')
        --WHERE
        --od.OrderType_ID IN (1, 9, 22, 23)
        --AND od.Process = 1 AND od.Filled = 1 AND od.Void = 0
        --ORDER BY ds.DealerCommissionDetailID


        DROP TABLE IF EXISTS #MPPOOrder;

        CREATE TABLE #MPPOOrder
        (
            MPOrderNo INT, accountID INT, MPProductID INT, ESN VARCHAR(40)
        );

        INSERT INTO #MPPOOrder
        SELECT
            MAX(o.Order_No) AS Order_No,
            o.Account_ID,
            o1.Product_ID,
            act.ESN
        FROM #ActivationOrder AS act
        JOIN dbo.tblOrderItemAddons AS po
            ON act.ESN = po.AddonsValue
        JOIN dbo.Orders AS o1
            ON o1.ID = po.OrderID
        JOIN dbo.Order_No AS o
            ON
                o.Order_No = o1.Order_No AND o.Filled = 1 AND o.Process = 1 AND o.Void = 0
                AND o.OrderType_ID IN (57, 58, 48, 49, 21)
        GROUP BY
            o.Account_ID,
            o1.Product_ID,
            act.ESN;


        --historical
        --INSERT INTO #MPPOOrder
        --SELECT
        --MAX(o.Order_No),
        --o.Account_ID,
        --o1.Product_ID,
        --act.ESN
        --FROM #ActivationOrder act
        --JOIN CellDay_History.dbo.tblOrderItemAddons po
        --ON act.ESN = po.AddonsValue
        --JOIN CellDay_History.dbo.Orders o1
        --ON o1.ID = po.OrderID
        --JOIN CellDay_History.dbo.Order_No o
        --ON o.Order_No = o1.Order_No AND o.Filled = 1 AND o.Process = 1 AND o.Void = 0
        --AND o.OrderType_ID IN ( 57, 58, 48, 49,21 )
        --AND NOT EXISTS (SELECT 1 FROM #MPPOOrder AS d WHERE d.ESN = act.ESN AND d.accountID = o.Account_ID)
        --GROUP BY
        --o.Account_ID,
        --o1.Product_ID,act.ESN
        --

        ; WITH cteFinal AS (
            SELECT DISTINCT
                ds.DealerCommissionDetailID
                , ds.Transaction_Date
                , ds.TSP_ID
                , a.ParentAccount_Account_ID AS [MAID]
                , ds.SIM AS SIM
                , ds.Commission_Amount
                , ro.Residual_OrderNumber
                , ro.Commission_Amount_Total
                , ro.Residual_DateFilled
                , ao.Activation_Order_No
                , ao.ActivationAccountID
                , ds.BillItemNumber --KMH20240304
                , IIF(ISNULL(ao.esn, '') LIKE '', ds.ESN, ao.esn) AS ESN
                , mp.MPOrderNo
                , mp.MPProductID
            FROM #DataStuff AS ds
            LEFT JOIN #ResidualOrder AS ro
                ON
                    ro.TSP_ID = ds.TSP_ID
                    AND ds.Create_Date = ro.Create_Date
            LEFT JOIN #ActivationOrder AS ao
                ON
                    ao.TSP_ID = ds.TSP_ID
                    AND ao.BillItemNumber = ds.BillItemNumber
                    --AND ao.ESN = ds.ESN
            JOIN dbo.Account AS a
                ON a.Account_ID = ds.TSP_ID
            LEFT JOIN #MPPOOrder AS mp
                ON mp.ESN = ao.ESN AND mp.accountID = ds.TSP_ID
        --AND ao.RowNum = 1
        )
        SELECT
            F.Transaction_Date
            , F.TSP_ID
            , F.MAID
            , F.ESN
            , F.SIM
            , F.Commission_Amount
            , F.Residual_OrderNumber
            , F.Commission_Amount_Total
            , F.Residual_DateFilled
            , F.Activation_Order_No
            , F.ActivationAccountID
            , F.BillItemNumber --KMH20240304
            , F.MPOrderNo
            , F.MPProductID
            , F.DealerCommissionDetailID
        FROM cteFinal AS F
        WHERE 1 = 1
        ORDER BY F.Residual_OrderNumber, F.ESN

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

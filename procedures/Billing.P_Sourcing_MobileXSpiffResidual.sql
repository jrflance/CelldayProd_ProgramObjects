--liquibase formatted sql

--changeset KarinaMasihHudson:441f8d3b1dfe4942bea0e4925d4653f9 stripComments:false runOnChange:true splitStatements:false
/*=============================================
       Author : Karina Masih-Hudson
  Create Date : 2024-03-27
  Description : Payout for MobileX following existing processes using database instead of file
 SSIS Package : .dtsx
          Job :
 =============================================*/

CREATE OR ALTER PROCEDURE [Billing].[P_Sourcing_MobileXSpiffResidual]
    (@StartDate DATETIME, @EndDate DATETIME)
AS

BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        --DECLARE
        --@StartDate DATETIME = '2024-02-17' --NULL
        --, @EndDate DATETIME = '2024-02-18' --NULL

        IF @StartDate IS NULL
            SET @StartDate = DATEADD(DAY, -7, CONVERT(DATE, GETDATE()))
        IF @EndDate IS NULL
            SET @EndDate = CONVERT(DATE, GETDATE())

        DECLARE @CarrierID INT = 302

        DECLARE @ErrMsg VARCHAR(512) = '';

        /****get all orders with the above products****/
        DROP TABLE IF EXISTS #TopUpAct
        SELECT DISTINCT
            o.ID AS [TopUpOrderID]
            , CONVERT(VARCHAR(100), od.Order_No) AS TopUpOrderNo
            , od.Account_ID
            , 0.00 AS FVAmount
            , CONVERT(FLOAT, 0.00) AS MerchantAmount
            , od.DateFilled AS [TransDate]
            , CONVERT(VARCHAR(100), NULL) AS AccountNumber
            , CONVERT(VARCHAR(100), NULL) AS ESN
            , CONVERT(VARCHAR(100), NULL) AS SIM
            , CONVERT(VARCHAR(100), oia.AddonsValue) AS MDN
            , o.Product_ID
            , o.Price --plan amount without discounts/fees
            , acc.DiscountClass_ID
            , topacc.Account_ID AS [TopParent]
            , topacc.DiscountClass_ID AS [TopParentDiscount]
            , op.ID AS [ActivationOrderID]
            , odp.Order_No AS [ActivationOrderNo]
            , odp.DateFilled AS [ActivationDateFilled]
            , odp.OrderType_ID
            , NULL AS DateDiffFirstTopUp
            , NULL AS DateDiffOtherTopUp
            , NULL AS MonthCount
            , 0 AS [ProcessStatus]
            , -2 AS [FileID]		--no file
        INTO #TopUpAct
        FROM cellday_prod.dbo.Order_No AS od
        JOIN dbo.Account AS acc
            ON
                acc.Account_ID = od.Account_ID
                AND ISNULL(acc.IstestAccount, 0) = 0
        JOIN dbo.Account AS topacc
            ON topacc.Account_ID = ISNULL(dbo.fn_GetTopParent_NotTcetra_h(acc.Hierarchy), 2)
        JOIN cellday_prod.dbo.orders AS o
            ON od.Order_No = o.Order_No
        JOIN dbo.tblOrderItemAddons AS oia
            ON oia.OrderID = o.ID
        JOIN dbo.tblAddonFamily AS aof
            ON
                aof.AddonID = oia.AddonsID
                AND aof.AddonTypeName IN ('ReturnPhoneType', 'PhoneNumberType')
        JOIN dbo.tblOrderItemAddons AS oiap
            ON oiap.AddonsValue = oia.AddonsValue
        JOIN dbo.Orders AS op
            ON
                op.ID = oiap.OrderID
                AND op.ID <> o.ID
                AND ISNULL(op.ParentItemID, 0) IN (0, 1)
        JOIN Products.tblProductCarrierMapping AS pcm
            ON
                pcm.ProductId = op.Product_ID
                AND pcm.CarrierId = @CarrierID
        JOIN dbo.Order_No AS odp
            ON
                odp.Order_No = op.Order_No
                AND odp.OrderType_ID IN (22, 23) --org activation, RTR
                AND odp.Process = 1 AND odp.Filled = 1 AND odp.Void = 0
        WHERE
            od.Process = 1 AND od.Filled = 1 AND od.Void = 0
            AND od.OrderType_ID IN (1, 9)
            --AND od.DateFilled >= '2024-04-29' --'2024-04-12'
            --AND od.DateFilled < '2024-05-01' --'2024-04-18'
            AND od.DateFilled >= @StartDate
            AND od.DateFilled < @EndDate
            AND EXISTS (
                SELECT TOP 1 1
                FROM Products.CarrierPayoutMapping AS cpm
                WHERE
                    cpm.orderproductid = o.Product_ID
                    AND cpm.carrierid = @CarrierID
                    AND cpm.status = 1
            )
        ORDER BY MDN, od.DateFilled

        -- SELECT * FROM #TopUpAct order by activationdatefilled desc

        /****device data****/
        DROP TABLE IF EXISTS #AddOns

        /*Info from topup*/
        SELECT DISTINCT t.TopUpOrderID, oia.AddonsValue, aof.AddonTypeName
        INTO #AddOns
        FROM #TopUpAct AS t
        JOIN dbo.tblOrderItemAddons AS oia
            ON oia.OrderID = t.TopUpOrderID
        JOIN dbo.tblAddonFamily AS aof
            ON
                aof.AddonID = oia.AddonsID
                AND aof.AddonTypeName IN ('SIMType', 'SIMBYOPType', 'DeviceType', 'DeviceBYOPType', 'PhoneNumberType', 'AccountNumberType')

        /*Info from original activation*/
        INSERT INTO #AddOns
        SELECT t.TopUpOrderID, oia.AddonsValue, aof.AddonTypeName
        FROM #TopUpAct AS t
        JOIN dbo.tblOrderItemAddons AS oia
            ON oia.OrderID = t.ActivationOrderID
        JOIN dbo.tblAddonFamily AS aof
            ON
                aof.AddonID = oia.AddonsID
                AND aof.AddonTypeName IN ('SIMType', 'SIMBYOPType', 'DeviceType', 'DeviceBYOPType', 'PhoneNumberType', 'AccountNumberType')
        WHERE
            NOT EXISTS
            (
                SELECT TOP 1 1
                FROM #AddOns AS ao
                WHERE
                    ao.TopUpOrderID = t.TopUpOrderID
                    AND ao.AddonsValue = oia.AddonsValue
            )


        UPDATE t
        SET t.SIM = ao.AddonsValue
        --SELECT *
        FROM #TopUpAct AS t
        JOIN #AddOns AS ao
            ON ao.TopUpOrderID = t.TopUpOrderID
        WHERE
            ao.AddonTypeName IN ('SIMType', 'SIMBYOPType')
            AND t.SIM IS NULL

        UPDATE t
        SET t.ESN = ao.AddonsValue
        --SELECT *
        FROM #TopUpAct AS t
        JOIN #AddOns AS ao
            ON ao.TopUpOrderID = t.TopUpOrderID
        WHERE
            ao.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
            AND t.ESN IS NULL

        UPDATE t
        SET t.MDN = ao.AddonsValue
        --SELECT *
        FROM #TopUpAct AS t
        JOIN #AddOns AS ao
            ON ao.TopUpOrderID = t.TopUpOrderID
        WHERE
            ao.AddonTypeName IN ('PhoneNumberType')
            AND t.MDN IS NULL

        UPDATE t
        SET t.AccountNumber = ao.AddonsValue
        --SELECT *
        FROM #TopUpAct AS t
        JOIN #AddOns AS ao
            ON ao.TopUpOrderID = t.TopUpOrderID
        WHERE
            ao.AddonTypeName IN ('AccountNumberType')
            AND t.AccountNumber IS NULL

        -- SELECT * FROM #TopUpAct order by activationdatefilled desc

        /****month check****/
        /****check how many months have been topped up - this will determine if spiff or residual payout****/
        ; WITH
        cteMonthCount AS (
            SELECT ta.TopUpOrderID, COUNT(oia.OrderID) AS TopUpCount
            FROM #TopUpAct AS ta
            JOIN dbo.tblOrderItemAddons AS oia
                ON oia.AddonsValue = ta.MDN
            JOIN dbo.Orders AS o
                ON
                    o.ID = oia.OrderID
                    AND ISNULL(o.ParentItemID, 0) IN (0, 1)
            JOIN dbo.Order_No AS od
                ON
                    od.Order_No = o.Order_No
                    AND od.OrderType_ID IN (1, 9)
                    AND od.Process = 1
                    AND od.Filled = 1
                    AND od.Void = 0
            GROUP BY
                ta.TopUpOrderID
                , ta.MDN
        )
        UPDATE ta
        SET ta.MonthCount = c.TopUpCount
        --SELECT *
        FROM cteMonthCount AS c
        JOIN #TopUpAct AS ta
            ON ta.TopUpOrderID = c.TopUpOrderID

        ------ SELECT * FROM #TopUpAct order by activationdatefilled desc


        UPDATE ta
        SET
            ta.DateDiffFirstTopUp = DATEDIFF(MONTH, ta.ActivationDateFilled, ta.TransDate)
            , ta.DateDiffOtherTopUp = NULL
        --SELECT DATEDIFF(MONTH, ta.ActivationDateFilled, ta.TransDate)
        FROM #TopUpAct AS ta
        WHERE DATEDIFF(MONTH, ta.ActivationDateFilled, ta.TransDate) IN (-1, 1)

        --DECLARE @CarrierID INT = 302

        UPDATE ta
        SET
            ta.DateDiffFirstTopUp = DATEDIFF(MONTH, ta.ActivationDateFilled, od.DateFilled)
            , ta.DateDiffOtherTopUp = DATEDIFF(MONTH, od.DateFilled, ta.TransDate)
        --SELECT ta.TopUpOrderID, ta.TopUpOrderNo, ta.TransDate, ta.ActivationOrderID, ta.ActivationOrderNo, ta.ActivationDateFilled
        --, ta.MonthCount, DATEDIFF(MONTH, ta.ActivationDateFilled, od.DateFilled) AS FirstTU, DATEDIFF(MONTH, od.DateFilled, ta.TransDate) AS OTU
        FROM #TopUpAct AS ta
        JOIN dbo.tblOrderItemAddons AS oia
            ON
                oia.AddonsValue = ta.MDN
                AND oia.OrderID <> ta.TopUpOrderID
        JOIN dbo.Orders AS o
            ON
                o.ID = oia.OrderID
                AND o.ID <> ta.TopUpOrderID
                AND ISNULL(o.ParentItemID, 0) IN (0, 1)
        JOIN dbo.Order_No AS od
            ON
                od.Order_No = o.Order_No
                AND od.OrderType_ID IN (1, 9)
                AND od.Process = 1
                AND od.Filled = 1
                AND od.Void = 0
                AND EXISTS
                (
                    SELECT TOP 1 1
                    FROM Products.CarrierPayoutMapping AS cpm
                    WHERE
                        cpm.orderproductid = o.Product_ID
                        AND cpm.ordertype LIKE 'RTR'
                        AND cpm.carrierid = @CarrierID
                        AND cpm.status = 1
                )

        DELETE
        --SELECT * , MonthCount * -1, ISNULL(DateDiffFirstTopUp, 0) + ISNULL(DateDiffOtherTopUp, 0)
        FROM #TopUpAct
        WHERE
            ISNULL(DateDiffFirstTopUp, 0) + ISNULL(DateDiffOtherTopUp, 0) <> MonthCount
            AND ISNULL(DateDiffFirstTopUp, 0) + ISNULL(DateDiffOtherTopUp, 0) <> (MonthCount * -1)

        ---- SELECT * FROM #TopUpAct order by activationdatefilled desc

        /****organize data that will go into #Base; get payout amounts going to merchant based on spiff/residual product id****/
        --DECLARE @CarrierID INT = 302
        DROP TABLE IF EXISTS #PreBase
        CREATE TABLE [#PreBase]
        (
            [TopUpOrderID] INT NOT NULL,
            [TopUpOrderNo] INT,
            [Account_ID] INT,
            [FVAmount] DECIMAL(9, 2),
            [MerchantAmount] FLOAT,
            [TransDate] DATETIME,
            [AccountNumber] VARCHAR(100),
            [ESN] VARCHAR(100),
            [SIM] VARCHAR(100),
            [MDN] VARCHAR(100),
            [Product_ID] INT,
            [PlanPrice] DECIMAL(9, 2),
            [DiscountClass_ID] INT,
            [ActivationOrderID] INT NOT NULL,
            [ActivationOrderNo] INT NOT NULL,
            [ActivationOrderTypeID] INT,
            [MonthCount] INT,
            [TopParent] INT NOT NULL,
            [TopParentDiscount] INT,
            [PayoutProductID] INT,
            [BPProcessTypeID] INT,
            [BPPaymentID] INT,
            [RowNum] INT,
            [ProcessStatus] INT,
            [FileID] INT
        )


        INSERT INTO #PreBase
        SELECT
            d.TopUpOrderID
            , d.TopUpOrderNo
            , d.Account_ID
            , d.FVAmount
            , d.MerchantAmount
            , d.TransDate
            , d.AccountNumber
            , d.ESN
            , d.SIM
            , d.MDN
            , d.Product_ID
            , d.Price
            , d.DiscountClass_ID
            , d.ActivationOrderID
            , d.ActivationOrderNo
            , d.OrderType_ID
            , d.MonthCount
            , d.TopParent
            , d.TopParentDiscount
            , d.PayoutProductID
            , d.BPProcessTypeID
            , NULL AS [BPPaymentID]
            , ROW_NUMBER() OVER (ORDER BY d.ActivationOrderNo) AS RNO
            , d.ProcessStatus
            , d.FileID
        FROM
            (
                SELECT
                    t.TopUpOrderID
                    , t.TopUpOrderNo
                    , t.Account_ID
                    , t.FVAmount
                    , t.MerchantAmount
                    , t.TransDate
                    , t.AccountNumber
                    , t.ESN
                    , t.SIM
                    , t.MDN
                    , t.Product_ID
                    , t.Price
                    , t.DiscountClass_ID
                    , t.ActivationOrderID
                    , t.ActivationOrderNo
                    , t.OrderType_ID
                    , t.MonthCount
                    , t.TopParent
                    , t.TopParentDiscount
                    , cpm.PayoutProductID
                    , cpm.BPProcessTypeID
                    , NULL AS [BPPaymentID]
                    , NULL AS RNO
                    , t.ProcessStatus
                    , t.FileID
                FROM #TopUpAct AS t
                JOIN Products.CarrierPayoutMapping AS cpm
                    ON
                        cpm.orderproductid = t.Product_ID
                        AND cpm.carrierid = @CarrierID
                        AND cpm.status = 1
                        AND cpm.payoutmonthstart <= t.MonthCount
                        AND ISNULL(cpm.payoutmonthend, 1000) > t.MonthCount
                UNION
                SELECT
                    t.TopUpOrderID
                    , t.TopUpOrderNo
                    , t.Account_ID
                    , t.FVAmount
                    , t.MerchantAmount
                    , t.TransDate
                    , t.AccountNumber
                    , t.ESN
                    , t.SIM
                    , t.MDN
                    , t.Product_ID
                    , t.Price
                    , t.DiscountClass_ID
                    , t.ActivationOrderID
                    , t.ActivationOrderNo
                    , t.OrderType_ID
                    , t.MonthCount
                    , t.TopParent
                    , t.TopParentDiscount
                    , cpm.PayoutProductID
                    , cpm.BPProcessTypeID
                    , NULL AS [BPPaymentID]
                    , NULL AS RNO
                    , t.ProcessStatus
                    , t.FileID
                FROM #TopUpAct AS t
                JOIN dbo.Products AS op
                    ON op.Product_ID = t.Product_ID
                JOIN dbo.Products AS pp
                    ON CONCAT(op.Name, ' RTR') = pp.Name
                JOIN Products.CarrierPayoutMapping AS cpm
                    ON
                        cpm.OrderProductID = pp.Product_ID
                        AND cpm.CarrierID = @CarrierID
                        AND cpm.status = 1
                        AND cpm.payoutmonthstart <= t.MonthCount
                        AND ISNULL(cpm.payoutmonthend, 1000) > t.MonthCount
            ) AS d

        --SELECT * FROM #TopUpAct
        --SELECT * FROM #PreBase

        /*Remove if already paid out*/
        DELETE d
        --Select *
        FROM
            (
                SELECT pb.TopUpOrderID
                FROM #PreBase AS pb
                WHERE
                    EXISTS
                    (
                        SELECT 1
                        FROM dbo.Order_No AS od
                        JOIN dbo.Orders AS o
                            ON
                                o.Order_No = od.Order_No
                                AND o.Product_ID = pb.PayoutProductID
                        JOIN Products.CarrierPayoutMapping AS cpm
                            ON
                                cpm.PayoutProductID = pb.PayoutProductID
                                AND cpm.carrierid = @CarrierID
                                AND cpm.status = 1
                                AND cpm.PayoutMonthStart = pb.MonthCount
                                AND cpm.PayoutType LIKE 'Spiff'
                        WHERE
                            od.Process = 1 AND od.Filled = 1 AND od.Void = 0
                            AND od.AuthNumber = CONVERT(VARCHAR(50), pb.ActivationOrderNo)
                            AND od.OrderType_ID IN (30, 34) --additional spiff
                    )
            ) AS d

        /*Dealer spiff payout amount*/
        UPDATE pb
        SET pb.MerchantAmount = ISNULL(dcp.Discount_Amt, 0.00)
        --SELECT pb.TopUpOrderID, pb.MerchantAmount, pb.Product_ID, pb.TopParent, pb.payoutproductid, dcp.DiscountClass_ID, dcp.Discount_Amt
        FROM #PreBase AS pb
        JOIN dbo.DiscountClass_Products AS dcp
            ON
                dcp.Product_ID = pb.PayoutProductID
                AND dcp.DiscountClass_ID = pb.DiscountClass_ID
                AND dcp.ApprovedToSell_Flg = 1
                AND dcp.Percent_Amount_Flg LIKE 'A'

        /*Residual*/
        UPDATE pb
        SET pb.MerchantAmount = ISNULL(ROUND(dcp.Discount_Amt / 100, 2) * pb.PlanPrice, 0.00)
        --SELECT pb.TopUpOrderID, pb.MerchantAmount, pb.TopParent, pb.payoutproductid, dcp.Discount_Amt, ROUND(dcp.Discount_Amt/100, 2)*pb.PlanPrice
        FROM #PreBase AS pb
        JOIN dbo.DiscountClass_Products AS dcp
            ON
                dcp.Product_ID = pb.PayoutProductID
                AND dcp.DiscountClass_ID = pb.DiscountClass_ID
                AND dcp.ApprovedToSell_Flg = 1
                AND dcp.Percent_Amount_Flg LIKE 'P'

        --SELECT * FROM #PreBase AS pb

        /****data that will go into billing tables for merchant payout****/
        DROP TABLE IF EXISTS #Base
        SELECT DISTINCT
            CONVERT(VARCHAR(100), pb.ActivationOrderNo) AS OOrderNo	---Needs to be original activation order number
            , pb.Account_ID
            , 0.00 AS FVAmount		--keep 0
            , pb.MerchantAmount  ---product DCP table amount
            , pb.TransDate
            , pb.AccountNumber
            , pb.ESN
            , pb.SIM
            , pb.MDN
            , pb.ProcessStatus
            , pb.BPProcessTypeID
            , pb.FileID
            , pb.RowNum AS RNo
        INTO #Base
        FROM #PreBase AS pb

        --SELECT * FROM #PreBase AS pb
        --SELECT * FROM #Base

        BEGIN TRAN
        DROP TABLE IF EXISTS #BPMapping
        CREATE TABLE #BPMapping
        (
            BillingPaymentID INT,
            RNO INT
        );

        MERGE billing.tblBillingPayments AS T
        USING #Base AS S
            ON 1 = 0
        WHEN NOT MATCHED BY TARGET
            THEN
            INSERT
                (
                    FileID,
                    AccountID,
                    FVAmount,
                    MerchantAmount,
                    TransactionDate,
                    BPStatusID,
                    StatusUpdated,
                    ParentCompanyID,
                    BPProcessTypeID
                )
            VALUES
                (
                    S.FileID, S.Account_id, S.FVAmount, S.MerchantAmount, S.TransDate, S.ProcessStatus, GETDATE(), 13, s.BPProcessTypeID
                )
        OUTPUT
            Inserted.BillingPaymentID,
            S.RNO
        INTO
            #BPMapping
            (
                BillingPaymentID,
                RNO
            );

        --SELECT * FROM billing.tblBillingPayments WHERE FileID = -2 AND BPStatusID = 0

        UPDATE pb
        SET pb.BPPaymentID = bp.BillingPaymentID
        --SELECT *
        FROM #PreBase AS pb
        JOIN #BPMapping AS bp
            ON pb.RowNum = bp.RNO


        DROP TABLE IF EXISTS #BPDataInsert
        SELECT
            unpiv.BillingPaymentID,
            unpiv.Data,
            unpiv.DataType
        INTO #BPDataInsert
        FROM
            (
                SELECT
                    b.OOrderNo            ---activation order
                    , b.ESN
                    , b.SIM
                    , b.MDN
                    , b.AccountNumber
                    , m.BillingPaymentID
                FROM #Base AS b
                JOIN #BPMapping AS m
                    ON b.RNO = m.RNO
            ) AS X
        UNPIVOT ([Data] FOR DataType IN (OOrderNo, ESN, SIM, MDN, AccountNumber)) AS unpiv;

        INSERT INTO billing.tblBPData
        (
            Data,
            DataType
        )
        SELECT DISTINCT
            di.Data,
            di.DataType
        FROM #BPDataInsert AS di
        WHERE
            NOT EXISTS
            (
                SELECT 1
                FROM billing.tblBPData AS bpd
                WHERE
                    bpd.DataType = di.DataType
                    AND bpd.Data = di.Data
            )
            AND ISNULL(di.Data, '') <> '';

        INSERT INTO billing.tblBPDataMapping
        (
            BillingPaymentID,
            BPDataID
        )
        SELECT
            di.BillingPaymentID,
            MAX(bpd.BPDataID) AS BPDataID
        FROM #BPDataInsert AS di
        JOIN billing.tblBPData AS bpd
            ON
                bpd.Data = di.Data
                AND bpd.DataType = di.DataType
        GROUP BY
            di.BillingPaymentID,
            bpd.DataType;

        --SELECT * FROM billing.tblBPData AS bd WHERE bd.BPDataID IN (
        --SELECT bpd.BPDataID FROM Billing.tblBPDataMapping AS bpd
        --JOIN billing.tblBillingPayments AS bp ON bp.BillingPaymentID = bpd.BillingPaymentID
        --WHERE bpd.BPDataID = bd.BPDataID AND bp.FileID = -2 AND bp.BPStatusID = 0)

        /****GET the amounts the MA will get paid****/
        DROP TABLE IF EXISTS #CalculateMAAmount

        /*residual*/
        SELECT DISTINCT
            bm.BillingPaymentID
            , pb.TopParent
            , ISNULL(ROUND(((dcp.Discount_Amt / 100) * pb.PlanPrice) - b.MerchantAmount, 2), 0.00) AS MAAmount
            , b.Account_ID
            , b.MerchantAmount
            , b.OOrderNo
            , b.RNO
            , pb.PayoutProductID
        INTO #CalculateMAAmount
        FROM #Base AS b
        JOIN #BPMapping AS bm
            ON bm.RNO = b.RNO
        JOIN #PreBase AS pb
            ON
                pb.ActivationOrderNo = b.OOrderNo
                AND pb.BPPaymentID = bm.BillingPaymentID
        JOIN dbo.Account AS acc
            ON acc.Account_ID = pb.TopParent
        JOIN dbo.DiscountClass_Products AS dcp
            ON
                dcp.Product_ID = pb.PayoutProductID
                AND dcp.DiscountClass_ID = acc.DiscountClass_ID
                AND dcp.ApprovedToSell_Flg = 1
                AND dcp.Percent_Amount_Flg LIKE 'P'

        ; WITH cteMAResidual AS (
            SELECT *
            FROM #CalculateMAAmount
        )
        INSERT INTO #CalculateMAAmount
        SELECT DISTINCT
            bm.BillingPaymentID
            , 2 AS [MAAccountID]
            , ISNULL(ROUND((((dcp.Discount_Amt + 1) / 100) * pb.PlanPrice) - cma.MAAmount - b.MerchantAmount, 2), 0.00) AS MAAmount
            , b.Account_ID
            , 0 AS MerchantAmount
            , b.OOrderNo
            , 0 AS RNo
            , pb.PayoutProductID
        FROM #Base AS b
        JOIN #BPMapping AS bm
            ON bm.RNO = b.RNO
        JOIN #PreBase AS pb
            ON
                pb.ActivationOrderNo = b.OOrderNo
                AND pb.BPPaymentID = bm.BillingPaymentID
        JOIN cteMAResidual AS cma
            ON cma.BillingPaymentID = bm.BillingPaymentID
        JOIN dbo.Account AS acc
            ON acc.Account_ID = 2
        JOIN dbo.DiscountClass_Products AS dcp
            ON
                dcp.Product_ID = pb.PayoutProductID
                AND dcp.DiscountClass_ID = acc.DiscountClass_ID
                AND dcp.ApprovedToSell_Flg = 1
                AND dcp.Percent_Amount_Flg LIKE 'P'

        --SELECT * FROM #CalculateMAAmount

        INSERT INTO Billing.tblBPMAAmount
        (
            BillingPaymentID,
            MAAccountId,
            Amount
        )
        SELECT
            BillingPaymentID
            , TopParent
            , MAAmount
        FROM #CalculateMAAmount

        --SELECT *
        --FROM Billing.tblBPMAAmount
        --WHERE BillingPaymentID IN (SELECT  BillingPaymentID
        --FROM billing.tblBillingPayments WHERE FileID = -2 AND BPStatusID = 0)


        COMMIT TRAN
    END TRY
    BEGIN CATCH
        SET @ErrMsg = ERROR_MESSAGE()
        ROLLBACK TRAN

        RAISERROR (@ErrMsg, 16, 1)
    END CATCH
END;

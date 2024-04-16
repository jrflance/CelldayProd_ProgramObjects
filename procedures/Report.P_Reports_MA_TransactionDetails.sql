--liquibase formatted sql

--changeset KarinaMasihHudson:93394c11aa2d4904a99b6b3cca26c206 stripComments:false runOnChange:true splitStatements:false
/*==============================================================================================================
           Rework  : Nicolas Griesdorn
           Date    : 01-25-2024
   Original Author : Melissa Rios
Originally Created : 2020-09-21
       Description : Used in SSRS to email at the end of each day that day's transactions.
	    BS20231102 : Added MA Account name and Id
	   KMH20231219 : If linked user created a transaction, map it to main user ID from linking table
	   KMH20231222 : Added Payment Status column
	   NG20240119  : Added the ability for multiple MA's to use report instead of hardcoding for Victra,added Address details as well
	   KMH20240221 : Updated Trac Autopay Enrollment Bonus/Trac Autopay Residual orders to display ESN and SIM
                   : Added MA Name/Account ID for all orders, Bill Item ID, Non-Commission Reason for $0 commissions,
					 Updated 'Spiff' to 'Commission' for Description
					 Updated SIMs displaying on Total by Verizon SIM Kit
					 Removed ParentItem consideration for Instant spiff - changed to review product type
					 Spiff product type = "Instant Spiff"; Fee product type = "Activation Fee"
					 Made sure subsidies only come in if activation is filled; bring in subsidies for newly filled activations
					 Remove Batch Number
					 Add UniqueID
					 - In cases where commission was generated, use Orders_ID, Order_Commission_SK from Order_Commission
					 - In cases with no commission, generate a $0 for parent and use Order.ID and ParentAccountID
					 Add $0 commission line for all MAs in an account tree not already being reported
	   KMH20240415 : Updated final join for MA display; was only displaying top
Original Procedure : [Report].[P_Reports_TransactionDetails] by MRios

================================================================================================================
             Usage : EXEC [Report].[P_Reports_MA_TransactionDetails]
================================================================================================================*/
ALTER PROCEDURE [Report].[P_Reports_MA_TransactionDetails]
    (@StartDate DATETIME, @EndDate DATETIME, @SessionID INT)
AS

BEGIN
    BEGIN TRY
    --  DECLARE
    --  @SessionID INT = 155536
    --  , @StartDate DATETIME = '2023-03-01' --NULL
    --  , @EndDate DATETIME = '2024-03-12' --NULL
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #ListOfAccounts;

        CREATE TABLE #ListOfAccounts (AccountID INT);

        IF
            (SELECT a.AccountType_ID FROM dbo.Account AS a WHERE a.Account_ID = @SessionID) IN (5, 6, 8)
            BEGIN
                INSERT INTO #ListOfAccounts (AccountID)
                EXEC [Account].[P_Account_GetAccountList]
                    @AccountID = @SessionID               -- int
                    , @UserID = 1                          -- int
                    , @AccountTypeID = '2,11'              -- varchar(50)
                    , @AccountStatusID = '0,1,2,3,4,5,6,7' -- varchar(50)
                    , @Simplified = 1;                     -- bit
            END;

        INSERT INTO #ListOfAccounts (AccountID)
        SELECT @SessionID
        WHERE
            @SessionID NOT IN (SELECT AccountID FROM #ListOfAccounts);

        ---------------------------------------------------------------------------------------------------------------
        IF @StartDate IS NULL
            SET @StartDate = CONVERT(DATE, DATEADD(DAY, -1, GETDATE()))

        IF @EndDate IS NULL
            SET @EndDate = CONVERT(DATETIME, CONVERT(DATE, GETDATE()));
        --------------------------------------------------------------------------------------------------------------
        -- Get orders based on Account and date (one day back)
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #OrderNo;

        SELECT
            Oi.ID
            , Oi.Order_No
            , CONVERT(BIGINT, n.AuthNumber) AS AuthNumber
            , n.OrderType_ID --KMH20240221
        INTO #OrderNo
        FROM #ListOfAccounts AS l
        JOIN dbo.Order_No AS n --WITH (INDEX (Ix_OrderNo_DateFilled))
            ON l.AccountID = n.Account_ID
        JOIN dbo.Orders AS Oi
            ON n.Order_No = Oi.Order_No
        WHERE
            n.DateFilled >= @StartDate
            AND n.DateFilled < @EndDate;
        --

        --KMH20240221 Find promos where activation filled later
        INSERT INTO #OrderNo (ID, Order_No, AuthNumber, OrderType_ID)
        SELECT DISTINCT
            opromo.ID
            , odpromo.Order_No
            , CONVERT(INT, odpromo.AuthNumber) AS AuthNumber
            , odpromo.OrderType_ID
        FROM #OrderNo AS d
        JOIN dbo.Order_No AS odpromo
            ON odpromo.AuthNumber = CONVERT(VARCHAR(30), d.Order_No)
        JOIN dbo.Orders AS opromo
            ON opromo.Order_No = odpromo.Order_No
        WHERE
            d.OrderType_ID IN (22, 23)
            AND odpromo.OrderType_ID IN (59, 60)
            AND odpromo.Process = 1
            AND odpromo.Filled = 1
            AND odpromo.Void = 0
            AND NOT EXISTS (SELECT TOP 1 1 FROM #OrderNo AS d2 WHERE d2.ID = opromo.ID)


        --KMH20240221 Remove promos where activation hasnt been filled
        ; WITH CTEPendingAct AS (
            SELECT
                d.ID AS RemoveID
            FROM #OrderNo AS d
            JOIN dbo.Order_No AS od2	--act
                ON
                    od2.Order_No = d.AuthNumber
                    AND od2.ordertype_id IN (22, 23)
            WHERE
                d.OrderType_ID IN (59, 60)
                AND (od2.Filled = 0 OR od2.void = 1)
        )
        DELETE
        --SELECT *
        FROM #OrderNo
        WHERE EXISTS (SELECT TOP 1 1 FROM CTEPendingAct AS c WHERE c.RemoveID = #OrderNo.ID)



        --------------------------------------------------------------------------------------------------------------
        -- Find order based on AuthNumber
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #OrderAuth;

        SELECT
            d2.ID
            , d2.Order_No
            , d2.ParentItemID
            , d2.ID AS OrderId
        INTO #OrderAuth
        FROM #OrderNo AS ord
        JOIN dbo.Orders AS d2
            ON d2.Order_No = ord.AuthNumber
        WHERE
            ISNULL(d2.ParentItemID, 0) IN (0, 1);
        --
        --------------------------------------------------------------------------------------------------------------
        -- Get data tblOrderItemAddons based on orders
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #OiA;

        SELECT A.*
        INTO #OiA
        FROM #OrderNo AS B
        JOIN dbo.tblOrderItemAddons AS A
            ON B.Id = A.OrderID;
        --
        --------------------------------------------------------------------------------------------------------------
        -- Get data tblOrderItemAddons based on AuthNumber
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #OIA2;

        SELECT
            A.*
            , B.Order_No
        INTO #OIA2
        FROM #OrderAuth AS B
        JOIN dbo.tblOrderItemAddons AS A
            ON B.ID = A.OrderID;
        --
        --------------------------------------------------------------------------------------------------------------
        -- Main data gather
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #Data;

        SELECT DISTINCT
            n.Account_ID
            , c.Address1 --NG20240119
            , c.Address2 --NG20240119
            , c.City --NG20240119
            , c.State --NG20240119
            , c.Zip --NG20240119
            , CONVERT(DATE, n.DateOrdered) AS DateOrdered
            , CONVERT(DATE, n.DateFilled) AS DateFilled
            , IIF(d.Name = 'Subsidy', CONCAT(d.Name, ' - ', pro.Name), d.Name) AS Product
            , CASE
                WHEN (
                    n.OrderType_ID IN (1, 9, 19) AND n.OrderTotal > 0
                    AND NOT EXISTS (SELECT TOP 1 1 FROM Products.CreditDebitProducts AS cd WHERE cd.Product_ID = d.product_id)
                )
                    THEN 'Top-Up'
                WHEN (
                    n.OrderType_ID IN (1, 9)
                    AND EXISTS (SELECT TOP 1 1 FROM Products.CreditDebitProducts AS cd2 WHERE cd2.Product_ID = d.product_id)
                )
                    THEN 'Credit Memo / Debit Memo' --KMH20240221
                WHEN n.OrderType_ID IN (61, 62) THEN 'Marketplace Return'
                --WHEN (n.OrderType_ID IN (22, 23) AND ISNULL(d.ParentItemID, 0) <> 0) THEN 'Instant Spiff'
                WHEN (n.OrderType_ID IN (22, 23) AND p.Product_Type = 4) THEN 'Instant Spiff' --KMH20240221
                WHEN (n.OrderType_ID IN (22, 23) AND p.Product_Type = 17) THEN 'Activation Fee' --KMH20240221
                WHEN n.OrderType_ID IN (22, 23) THEN 'Activation'
                WHEN n.OrderType_ID IN (48, 49, 57, 58) THEN 'Marketplace Purchase'
                --WHEN n.OrderType_ID IN (2, 3) THEN 'Credit Memo / Debit Memo'
                WHEN
                    n.OrderType_ID IN (59, 60)
                    AND d.Name LIKE '%month 2%' THEN 'Month 2 Promo Rebate'
                WHEN
                    n.OrderType_ID IN (59, 60)
                    AND d.Name LIKE '%month 3%' THEN 'Month 3 Promo Rebate'
                WHEN
                    n.OrderType_ID IN (59, 60)
                    AND (
                        d.Name LIKE '%Activation%'
                        AND d.Name LIKE '%Fee%'
                        AND d.Name LIKE '%Spiff%'
                    ) THEN 'Activation Fee Spiff'	--KMH20240221
                WHEN
                    n.OrderType_ID IN (59, 60)
                    AND (d.Name LIKE '%Activation%Fee%Spiff%') THEN 'Activation Fee Spiff'	--KMH20240221
                WHEN n.OrderType_ID IN (59, 60) THEN 'Instant Promo Rebate'
                WHEN
                    n.OrderType_ID IN (30, 34, 28, 38, 45, 46)
                    AND d.Name LIKE '%month 2%' THEN 'Month 2 Commission'	--KMH20240221
                WHEN
                    n.OrderType_ID IN (30, 34, 28, 38, 45, 46)
                    AND d.Name LIKE '%month 3%' THEN 'Month 3 Commission'	--KMH20240221
                WHEN
                    n.OrderType_ID IN (30, 34, 28, 38, 45, 46)
                    AND d.Name LIKE '%month 4%' THEN 'Month 4 Commission'	--KMH20240221
                WHEN
                    n.OrderType_ID IN (30, 34, 28, 38, 45, 46)
                    AND d.Name LIKE '%month 5%' THEN 'Month 5 Commission'	--KMH20240221
                WHEN
                    n.OrderType_ID IN (30, 34, 28, 38, 45, 46)
                    AND d.Name LIKE '%month 6%' THEN 'Month 6 Commission'	--KMH20240221
                WHEN n.OrderType_ID IN (45, 46) THEN 'Month 1 Commission'	--KMH20240221
                WHEN
                    n.OrderType_ID IN (28, 38)
                    AND d.Product_ID = 13119 THEN 'Month 1 Spiff'
                WHEN n.OrderType_ID IN (28, 38) THEN 'Residual'
                ELSE oti.OrderType_Desc
            END AS [Description]
            , n.Order_No AS [OrderNo]
            , STUFF(
                RIGHT(' ' + CONVERT(VARCHAR(7), DATEADD(HOUR, +1, CONVERT(TIME, n.DateOrdered)), 0), 7), 6, 0, ' '
            ) AS [Time (EST)]
            , ISNULL(n.AuthNumber, '') AS [ReferenceOrderNo]
            , ISNULL(aulu.UserName, u.UserName) AS [User Name]		---KMH20231219
            , ISNULL(d.Price, 0.00) AS Retail
            , ISNULL(d.DiscAmount, 0.00) AS [Discount]
            , ISNULL((ISNULL(d.Price, 0.00) - ISNULL(d.DiscAmount, 0.00) + ISNULL(d.Fee, 0.00)), 0.00) AS Cost
            , d.ID AS OrderID
            , d.ParentItemID
            --, obm.OrderBatchId AS [Batch#]
            , n.STATUS AS MerchantInvoiceNum
            , n1.DateDue AS MerchantDateDue
            , CASE WHEN n.Paid = 1 THEN 'Paid' ELSE 'Not Paid' END AS [Payment Status]			--KMH20231222
            , n.OrderType_ID --KMH20240221
            , d.SKU  --KMH20240221
        INTO #Data
        FROM #OrderNo AS ord
        JOIN dbo.Orders AS d
            ON
                ord.Order_No = d.Order_No
                AND d.ID = ord.ID
        JOIN dbo.Order_No AS n
            ON n.Order_No = d.Order_No
        JOIN dbo.Customers AS C
            ON C.Customer_ID = n.ShipTo
        JOIN dbo.Products AS p --KMH20240221
            ON p.Product_ID = d.Product_ID
        LEFT JOIN dbo.Order_No AS n1
            ON n.STATUS = CONVERT(VARCHAR(50), n1.Order_No)
        JOIN dbo.OrderType_ID AS oti
            ON oti.OrderType_ID = n.OrderType_ID
        JOIN dbo.Users AS u
            ON u.USER_ID = n.USER_ID
        LEFT JOIN account.tblAccountUserLink AS aul
            ON
                aul.LinkedUserID = n.USER_ID
                AND aul.AccountID = n.Account_ID
                AND aul.ACTIVE = 1
        LEFT JOIN dbo.Users AS aulu		--KMH20231219 Want the original UserID/name from linked that placed order
            ON aulu.USER_ID = aul.UserID
        LEFT JOIN Products.tblPromotion AS pro
            ON pro.PromotionId = d.Dropship_Qty
        LEFT JOIN OrderManagment.tblOrderBatchMapping AS obm
            ON obm.OrderNo = ord.Order_No
        WHERE
            n.Filled = 1
            AND n.Void = 0
            AND n.PROCESS = 1
            AND n.OrderType_ID NOT IN (12, 5, 6, 43, 44); --prepaid statement, invoice, Postpaid Second Refill, and Prepaid Second Refill
        --
        --------------------------------------------------------------------------------------------------------------
        -- Add in dbo.tblOrderItemAddons  data
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #Data2;

        SELECT DISTINCT
            d1.Account_ID
            , d1.Address1 --NG20240119
            , d1.Address2 --NG20240119
            , d1.City --NG20240119
            , d1.State --NG20240119
            , d1.Zip --NG20240119
            , d1.DateOrdered
            , d1.DateFilled
            , d1.Product
            , d1.Description
            , d1.OrderNo
            , d1.[Time (EST)]
            , d1.ReferenceOrderNo
            , d1.[User Name]
            , d1.Retail
            , d1.Discount
            , d1.Cost
            , d1.OrderID
            , d1.ParentItemID
            --, d1.[Batch#]
            , d1.MerchantInvoiceNum
            , d1.MerchantDateDue --NG20240119
            , d1.[Payment Status]			--KMH20231222
            , d1.OrderType_ID  --KMH20240221
            , d1.SKU  --KMH20240221
            , ISNULL(oia.AddonsValue, '') AS Phone
            , IIF(
                oia5.AddonsValue = 'on'
                , 'Port'
                , IIF(oia6.AddonsValue = 'on', 'Port', IIF(d1.Product LIKE '%port%', 'Port', ''))
            ) AS IsPort -- renamed for #Data
            , CONVERT(VARCHAR(50), '') AS SIM  -- Place holder
            , CONVERT(VARCHAR(50), '') AS ESN  -- Place holder
        INTO #Data2
        FROM #Data AS d1
        LEFT JOIN #OrderAuth AS d2
            ON d2.OrderId = d1.OrderID
        LEFT JOIN dbo.tblOrderItemAddons AS oia5
            ON
                d2.ID = oia5.OrderID
                AND oia5.AddonsID = 26
        LEFT JOIN dbo.tblOrderItemAddons AS oia6
            ON
                d1.OrderID = oia6.OrderID
                AND oia6.AddonsID = 26
        LEFT JOIN #OiA AS oia
            ON
                oia.OrderID = d1.OrderID
                AND oia.AddonsID IN (8, 23) --PhoneNumberType & ReturnPhoneType
                AND LEN(oia.AddonsValue) > 6;
        --

        DROP TABLE IF EXISTS #AccountTree; --KMH20240301

        ; WITH cteAccountTree AS (
            SELECT DISTINCT
                d.Account_ID
                , acc.Account_Name AS [ChildName]
                , acc.ParentAccount_Account_ID
                , acc.HierarchyString
            FROM #Data2 AS d
            JOIN dbo.Account AS acc
                ON acc.Account_ID = d.Account_ID
        )
        , cteHierarchy AS (
            SELECT
                c.Account_ID
                , c.ChildName
                , c.ParentAccount_Account_ID
                , c.HierarchyString
                , ISNULL(CONVERT(INT, s.[value]), 0) AS ParentAccounts
            FROM cteAccountTree AS c
            CROSS APPLY STRING_SPLIT(c.HierarchyString, '/') AS s
        )
        SELECT
            h.Account_ID
            , h.HierarchyString
            , IIF(h.ParentAccounts = 2, h.Account_ID, h.ParentAccounts) AS ParentAccounts
            , IIF(h.ParentAccounts = 2, h.ChildName, acc.Account_Name) AS Account_Name
            , ROW_NUMBER() OVER (PARTITION BY h.Account_ID ORDER BY h.ParentAccounts) AS AccountTree
            , IIF(h.ParentAccounts = h.ParentAccount_Account_ID, 1, 0) AS IsDirectParent
        INTO #AccountTree
        FROM cteHierarchy AS h
        JOIN dbo.Account AS acc
            ON acc.Account_ID = h.ParentAccounts
        WHERE
            (
                h.ParentAccounts NOT IN (0, 2)
                OR (
                    h.ParentAccounts = 2
                    AND IIF(h.ParentAccounts = h.ParentAccount_Account_ID, 1, 0) = 1
                )
            )
            AND h.Account_ID <> h.ParentAccounts


        DROP TABLE IF EXISTS #BillItem; --KMH20240221

        SELECT
            d.Account_ID
            , d.OrderNo
            , d.OrderID
            , d.DateFilled
            , d.BillItemNumber
        INTO #BillItem
        FROM
            (
                SELECT
                    dd.Account_ID
                    , dd.OrderNo
                    , dd.OrderID
                    , dd.DateFilled
                    , oia.AddonsValue AS [BillItemNumber]
                FROM #Data2 AS dd
                JOIN dbo.tblOrderItemAddons AS oia
                    ON
                        dd.OrderID = oia.OrderID
                        AND oia.AddonsID = 196
                UNION
                SELECT
                    dd.Account_ID
                    , dd.OrderNo
                    , dd.OrderID
                    , dd.DateFilled
                    , dd.SKU AS [BillItemNumber]
                FROM #Data2 AS dd
                WHERE OrderType_ID IN (30, 34, 28, 38, 45, 46)
            ) AS d


        INSERT INTO #BillItem	--KMH20240221
        SELECT
            dd.Account_ID
            , dd.OrderNo
            , dd.OrderID
            , dd.DateFilled
            , oia.AddonsValue AS [BillItemNumber]
        FROM #Data2 AS dd
        JOIN dbo.Orders AS refo
            ON dd.ReferenceOrderNo = CONVERT(BIGINT, refo.Order_No)
        JOIN dbo.tblOrderItemAddons AS oia
            ON
                refo.ID = oia.OrderID
                AND oia.AddonsID = 196

        ; WITH cteBillItem AS (
            SELECT
                d.OrderID
                , d.OrderNo
                , bi.Account_ID
                , bi.DateFilled
                , bi.BillItemNumber
            FROM #Data2 AS d
            LEFT JOIN #BillItem AS bi
                ON bi.OrderNo = d.OrderNo
        )
        INSERT INTO #BillItem
        SELECT
            c.Account_ID
            , c.OrderNo
            , c.OrderID
            , c.DateFilled
            , c.BillItemNumber
        FROM cteBillItem AS c

        DELETE d
        --SELECT *
        FROM
            (
                SELECT
                    Account_ID
                    , OrderNo
                    , OrderID
                    , DateFilled
                    , BillItemNumber
                    , ROW_NUMBER() OVER (PARTITION BY OrderID ORDER BY BillItemNumber DESC) AS Rnum
                FROM #BillItem
            ) AS d
        WHERE d.RNum <> 1

        DROP TABLE IF EXISTS #DCDData;--KMH20240221

        SELECT DISTINCT
            d.OrderID
            , d.OrderNo
            , d.Account_ID
            , dcd.TRANSACTION_DATE
            , dcd.ESN
            , dcd.SIM
            , dcd.RTR_TXN_REFERENCE1 AS [BillItemNumber]
            , dcd.COMMISSION_AMOUNT
            , dcd.COMMISSION_TYPE
            , IIF(dcd.COMMISSION_AMOUNT LIKE '0', dcd.NON_COMMISSIONED_REASON, '') AS Non_Commissioned_Reason
            , ISNULL(dcd.Create_Date, '1900-01-01') AS Create_Date
        INTO #DCDData
        FROM #BillItem AS d
        JOIN Tracfone.tblDealerCommissionDetail AS dcd
            ON
                d.BillItemNumber = dcd.RTR_TXN_REFERENCE1
                AND dcd.TSP_ID = CONVERT(VARCHAR(15), d.Account_ID)
        WHERE CONVERT(DATE, dcd.Create_Date) >= d.DateFilled


        INSERT INTO #DCDData
        SELECT
            d.OrderID
            , d.OrderNo
            , d.Account_ID
            , NULL AS Transaction_Date
            , dc.ESN AS ESN
            , dc.SIM AS SIM
            , dc.BillItemNumber
            , NULL AS Commission_Amount
            , NULL AS Commission_Type
            , '' AS Non_Commissioned_Reason
            , ISNULL(dc.Create_Date, '1900-01-01') AS Create_Date
        FROM #Data2 AS d
        LEFT JOIN #DCDData AS dc
            ON d.OrderID = dc.OrderID

        ----For historical run as dcd only keeps few weeks of data
        -- INSERT INTO #DCDData
        -- SELECT DISTINCT
        -- d.OrderID
        -- , d.OrderNo
        -- , d.Account_ID
        -- , dcd.TRANSACTION_DATE
        -- , dcd.ESN
        -- , dcd.SIM
        -- , dcd.RTR_TXN_REFERENCE1 AS [BillItemNumber]
        -- , dcd.COMMISSION_AMOUNT
        -- , dcd.COMMISSION_TYPE
        -- , IIF(dcd.COMMISSION_AMOUNT LIKE '0', dcd.NON_COMMISSIONED_REASON, '') AS Non_Commissioned_Reason
        -- , dcd.Create_Date
        -- FROM #BillItem AS d
        -- JOIN CellDay_History.Tracfone.tblDealerCommissionDetail AS dcd
        -- ON
        -- d.BillItemNumber = dcd.RTR_TXN_REFERENCE1
        -- AND dcd.TSP_ID = CONVERT(VARCHAR(15), d.Account_ID)
        -- WHERE CONVERT(DATE, dcd.Create_Date) >= d.DateFilled

        DELETE c
        --SELECT *
        FROM
            (
                SELECT
                    OrderID
                    , OrderNo
                    , TRANSACTION_DATE
                    , BillItemNumber
                    , COMMISSION_AMOUNT
                    , Non_Commissioned_Reason
                    , Create_Date
                    , ROW_NUMBER() OVER (PARTITION BY OrderID ORDER BY Create_Date DESC) AS RowNum
                FROM #DCDData
                WHERE COMMISSION_TYPE LIKE 'ACTIVATION SPIFF'
            ) AS c
        WHERE c.RowNum <> 1

        DROP TABLE IF EXISTS #ResidualDataPre; --KMH20240221

        SELECT DISTINCT
            d.OrderID
            , d.OrderNo
            , odr.Account_ID
            , d.Product
            , oiar.AddonsValue AS [SIM]
            , CASE
                WHEN dcd.esn IS NOT NULL THEN dcd.ESN
                WHEN
                    LEN(oia.AddonsValue) BETWEEN 15 AND 16
                    AND ISNUMERIC(oia.AddonsValue) = 1
                    THEN oia.AddonsValue
                ELSE ''
            END AS [ESN]
            , dcd.BillItemNumber
        INTO #ResidualDataPre
        FROM #Data2 AS d
        JOIN cellday_prod.dbo.Order_No AS odr
            ON odr.Order_No = d.OrderNo
        JOIN dbo.tblOrderItemAddons AS oiar
            ON oiar.OrderID = d.OrderID
        JOIN #DCDData AS dcd
            ON
                dcd.SIM = oiar.AddonsValue
                --AND dcd.COMMISSION_TYPE IN ('AUTOPAY ENROLLMENT','AUTOPAY RESIDUAL')
                AND ISNULL(dcd.ESN, '') NOT LIKE ''
        JOIN dbo.tblOrderItemAddons AS oias
            ON oias.AddonsValue = oiar.AddonsValue
        LEFT JOIN
            dbo.tblOrderItemAddons AS oia
                JOIN dbo.tblAddonFamily AS aof
                    ON
                        aof.AddonID = oia.AddonsID
                        AND aof.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
            ON oias.OrderID = oia.OrderID
        LEFT JOIN
            dbo.Orders AS o
                JOIN dbo.Order_No AS od
                    ON
                        od.Order_No = o.Order_No
                        AND od.OrderType_ID IN (22, 23)
            ON
                oia.OrderID = o.ID
                AND ISNULL(o.ParentItemID, 0) = 0
        WHERE odr.OrderType_ID IN (28, 38)


        DROP TABLE IF EXISTS #ResidualData; --KMH20240221
        ; WITH DupR AS (
            SELECT
                OrderID
                , OrderNo
                , Account_ID
                , Product
                , SIM
                , ESN
                , BillItemNumber
                , ROW_NUMBER() OVER (PARTITION BY OrderID ORDER BY BillItemNumber DESC) AS Rnum
            FROM #ResidualDataPre
        )
        SELECT
            c.OrderID
            , c.OrderNo
            , c.Account_ID
            , c.Product
            , c.SIM
            , c.ESN
            , c.BillItemNumber
            , c.Rnum
        INTO #ResidualData
        FROM DupR AS c
        WHERE c.Rnum = 1

        DROP TABLE IF EXISTS #ResidualDataPre

        --------------------------------------------------------------------------------------------------------------
        -- ESN
        --------------------------------------------------------------------------------------------------------------
        UPDATE d
        SET ESN = ISNULL(oia2.AddonsValue, ISNULL(oia4.AddonsValue, ISNULL(tf.TXN_PIN, ISNULL(rd.esn, ISNULL(dd.ESN, '')))))
        FROM #Data2 AS d
        LEFT JOIN #OrderAuth AS d2
            ON d2.OrderId = d.OrderID
        LEFT JOIN Tracfone.tblTSPTransactionFeed AS tf
            ON tf.Order_No = d.OrderNo
        LEFT JOIN
            #OiA AS oia4
                JOIN dbo.tblAddonFamily AS f3
                    ON
                        f3.AddonID = oia4.AddonsID
                        AND f3.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
            ON oia4.OrderID = d.OrderID
        LEFT JOIN
            #OIA2 AS oia2
                JOIN dbo.tblAddonFamily AS f
                    ON
                        f.AddonID = oia2.AddonsID
                        AND f.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
            ON oia2.OrderID = d2.OrderId
        LEFT JOIN #ResidualData AS rd --KMH20240221
            ON rd.OrderID = d.OrderID
        LEFT JOIN #DCDData AS dd --KMH20240221
            ON dd.OrderID = d.OrderID
        WHERE ISNULL(d.ESN, '') LIKE ''; --KMH20240221
        --

        UPDATE d
        SET d.ESN = ISNULL(d.SKU, '')
        --SELECT *
        FROM #Data2 AS d
        WHERE
            ISNULL(d.SKU, '') NOT LIKE ''
            AND ISNULL(d.ESN, '') LIKE ''
            AND LEN(d.SKU) = 15

        --------------------------------------------------------------------------------------------------------------
        -- SIM
        --------------------------------------------------------------------------------------------------------------
        UPDATE d
        SET d.SIM = ISNULL(oia3.AddonsValue, ISNULL(oia4.AddonsValue, ISNULL(dsim.SKU, ISNULL(rd.SIM, ISNULL(dd.SIM, '')))))
        FROM #Data2 AS d
        LEFT JOIN #OrderAuth AS d2
            ON d2.OrderId = d.OrderID
        LEFT JOIN --KMH20240221
            #OiA AS oia4
                JOIN dbo.tblAddonFamily AS f3
                    ON
                        f3.AddonID = oia4.AddonsID
                        AND f3.AddonTypeName IN ('SimType', 'SimBYOPType')
            ON oia4.OrderID = d.OrderID
        LEFT JOIN
            #OIA2 AS oia3
                JOIN dbo.tblAddonFamily AS f2
                    ON
                        f2.AddonID = oia3.AddonsID
                        AND f2.AddonTypeName IN ('SimType', 'SimBYOPType')
            ON oia3.OrderID = d2.OrderId
        LEFT JOIN #Data2 AS dsim --KMH20240221
            ON
                dsim.OrderID = d.OrderID
                AND dsim.Product LIKE 'Total by Verizon SIM Kit'
        LEFT JOIN #ResidualData AS rd --KMH20240221
            ON rd.OrderID = d.OrderID
        LEFT JOIN #DCDData AS dd --KMH20240221
            ON dd.OrderID = d.OrderID;

        ---------------------------------------------------------------------------------------------------------------
        -- Commission
        ---------------------------------------------------------------------------------------------------------------
        -- Logic modified from [Report].[P_Report_MA_Invoice_Commission_Details_With_Tree_Commissions]
        -- logic added to provide commission amounts

        DROP TABLE IF EXISTS #ListOfCommInfo;

        SELECT DISTINCT
            oc.Account_ID
            , ISNULL(a.Account_Name, '') AS Master_AccountName         --BS20231102
            , n.Order_No AS [MAInvoiceNumber]
            , oc.Orders_ID
            , oc.Commission_Amt
            , oc.Datedue
            , CONVERT(VARCHAR(MAX), '') AS Non_Commissioned_Reason --KMH20240221
            , CONCAT(oc.Orders_ID, oc.Order_Commission_SK) AS UniqueID --KMH20240221
        INTO #ListOfCommInfo
        FROM #Data AS d
        JOIN dbo.Order_Commission AS oc
            ON
                oc.Orders_ID = d.OrderID
                AND oc.Account_ID <> 2
        JOIN dbo.Account AS a                                 --BS20231102
            ON a.Account_ID = oc.Account_ID
        LEFT JOIN dbo.Order_No AS n
            ON
                CONVERT(VARCHAR(20), oc.InvoiceNum) = n.InvoiceNum
                AND n.Account_ID = oc.Account_ID
                AND n.OrderType_ID IN (5, 6);

        ; WITH cteDup AS ( --KMH20240221
            SELECT
                lci.Orders_ID
                , dd.BillItemNumber
                , dd.NON_COMMISSIONED_REASON
                , ROW_NUMBER() OVER (PARTITION BY dd.TRANSACTION_DATE ORDER BY dd.TRANSACTION_DATE DESC) AS Rnum
            FROM #ListOfCommInfo AS lci
            JOIN #DCDData AS dd
                ON dd.OrderID = lci.Orders_ID
            WHERE
                lci.Commission_Amt = 0
                AND dd.COMMISSION_AMOUNT LIKE '0'
                AND dd.COMMISSION_TYPE LIKE 'ACTIVATION SPIFF'
            GROUP BY
                lci.Orders_ID
                , dd.BillItemNumber
                , dd.NON_COMMISSIONED_REASON
                , dd.TRANSACTION_DATE
        )
        UPDATE lci
        SET lci.Non_Commissioned_Reason = c.NON_COMMISSIONED_REASON
        --SELECT *
        FROM cteDup AS c
        JOIN #ListOfCommInfo AS lci
            ON lci.Orders_ID = c.Orders_ID
        WHERE c.Rnum = 1

        INSERT INTO #ListOfCommInfo --KMH20240221
        SELECT
            d.ParentAccounts
            , d.Account_Name
            , d.MAInvoiceNumber
            , d.OrderID
            , d.Commission_Amt
            , d.Datedue
            , d.Non_Commissioned_Reason
            , d.UniqueID
        FROM
            (
                SELECT
                    act.ParentAccounts
                    , ISNULL(act.Account_Name, '') AS Account_Name
                    , 0 AS MAInvoiceNumber
                    , d.orderid
                    , 0.00 AS Commission_Amt
                    , '1900-01-01' AS Datedue
                    , '' AS Non_Commissioned_Reason
                    , CONCAT(d.orderid, act.ParentAccounts) AS UniqueID
                FROM #Data2 AS d
                JOIN #AccountTree AS act
                    ON act.Account_ID = d.Account_ID
                WHERE NOT EXISTS (
                    SELECT TOP 1 1
                    FROM #ListOfCommInfo AS lc
                    WHERE
                        d.OrderID = lc.Orders_ID
                        AND lc.Account_ID = act.ParentAccounts
                )
            ) AS d
        --
        --------------------------------------------------------------------------------------------------------------
        -- Get final data and add totals
        --------------------------------------------------------------------------------------------------------------
        DROP TABLE IF EXISTS #Results;

        SELECT DISTINCT
            d.OrderID
            , CONVERT(VARCHAR(20), d.Account_ID) AS Account_ID
            , a.Account_Name
            , d.Address1 --NG20240119
            , d.Address2 --NG20240119
            , d.City --NG20240119
            , d.State --NG20240119
            , d.Zip --NG20240119
            , CONVERT(VARCHAR(20), d.DateOrdered) AS DateOrdered
            , CONVERT(VARCHAR(20), d.DateFilled) AS DateFilled
            , d.Product
            , d.Description
            , d.IsPort
            , d.[Time (EST)]
            , CONVERT(VARCHAR(25), d.OrderNo) AS OrderNo
            , d.ReferenceOrderNo
            , d.[User Name]
            , ISNULL(d.SIM, '') AS SIM
            , ISNULL(d.ESN, '') AS ESN
            , d.Phone
            , d.Retail
            , d.Discount
            , d.Cost
            -- These are added as per request
            , ISNULL(CONVERT(VARCHAR(20), lci.MAInvoiceNumber), '') AS MAInvoiceNumber
            , ISNULL(CONVERT(VARCHAR(20), lci.Commission_Amt), '') AS Commission_Amt
            , ISNULL(CONVERT(VARCHAR(20), lci.Datedue), '') AS [MA DateDue] --NG20240119
            , CONVERT(VARCHAR(20), ISNULL(act.ParentAccounts, ISNULL(lci.Account_ID, ''))) AS Master_AccountID	--BS20231102
            , ISNULL(act.Account_Name, ISNULL(lci.Master_AccountName, '')) AS Master_AccountName	--BS20231102
            , ISNULL(CONVERT(VARCHAR(20), d.MerchantInvoiceNum), '') AS MerchantInvoiceNumber
            , CONVERT(VARCHAR(20), d.MerchantDateDue) AS [Merchant DateDue] --NG20240119
            , d.[Payment Status]			--KMH20231222
            , ISNULL(bi.BillItemNumber, ISNULL(rd.BillItemNumber, ISNULL(dcd.BillItemNumber, ''))) AS BillItemNumber --KMH20240221
            , IIF(lci.Commission_Amt = 0, ISNULL(lci.NON_COMMISSIONED_REASON, ''), '') AS Non_Commissioned_Reason --KMH20240221
            , lci.UniqueID --KMH20240221
        INTO #Results
        FROM #Data2 AS d
        JOIN dbo.Account AS a
            ON a.Account_ID = d.Account_ID
        JOIN #AccountTree AS act
            ON
                act.Account_ID = d.Account_ID
                --AND act.IsDirectParent = 1
        LEFT JOIN #ListOfCommInfo AS lci
            ON
                lci.Orders_ID = d.OrderID
                AND lci.Account_ID = act.ParentAccounts
        LEFT JOIN #BillItem AS bi --KMH20240221
            ON bi.OrderID = d.OrderID
        LEFT JOIN #ResidualData AS rd --KMH20240221
            ON rd.OrderID = d.OrderID
        LEFT JOIN #DCDData AS dcd
            ON dcd.OrderID = d.OrderID
        UNION
        SELECT
            '' AS OrderID
            , '' AS Account_ID
            , '' AS Account_Name
            , '' AS Address1 --NG20240119
            , '' AS Address2 --NG20240119
            , '' AS City --NG20240119
            , '' AS State --NG20240119
            , '' AS Zip --NG20240119
            , '' AS DateOrdered
            , '' AS DateFilled
            , '' AS Product
            , 'Total Debits' AS Description
            , '' AS IsPort
            , '' AS [Time (EST)]
            , '' AS OrderNo
            , '' AS ReferenceOrderNo
            , '' AS [User Name]
            --, '' AS [Batch#]
            , '' AS SIM
            , '' AS ESN
            , '' AS Phone
            , 0 AS Retail
            , 0 AS Discount
            , SUM(d2.Cost) AS [Cost]
            , '' AS MaInvoiceNumber
            , '' AS Commission_Amt
            , '' AS [MA DateDue] --NG20240119
            , '' AS Master_AccountID
            , '' AS Master_AccountName								--BS20231102
            , '' AS [Payment Status]			--KMH20231222
            , '' AS InvoiceNum
            , '' AS [Merchant DateDue] --NG20240119
            , '' AS BillItemNumber --KMH20240221
            , '' AS Non_Commissioned_Reason --KMH20240221
            , '' AS UniqueID --KMH20240221
        FROM #Data2 AS d2
        WHERE d2.Cost > 0
        UNION
        SELECT
            '' AS OrderID
            , '' AS Account_ID
            , '' AS Account_Name
            , '' AS Address1 --NG20240119
            , '' AS Address2 --NG20240119
            , '' AS City --NG20240119
            , '' AS State --NG20240119
            , '' AS Zip --NG20240119
            , '' AS DateOrdered
            , '' AS DateFilled
            , '' AS Product
            , 'Total Credits' AS Description
            , '' AS IsPort
            , '' AS [Time (EST)]
            , '' AS OrderNo
            , '' AS ReferenceOrderNo
            , '' AS [User Name]
            , '' AS SIM
            , '' AS ESN
            , '' AS Phone
            , 0 AS Retail
            , 0 AS Discount
            , SUM(d2.Cost) AS [Cost]
            , '' AS MaInvoiceNumber
            , '' AS Commission_Amt
            , '' AS [MA DateDue] --NG20240119
            , '' AS Master_AccountID
            , '' AS Master_AccountName							--BS20231102
            , '' AS [Payment Status]			--KMH20231222
            , '' AS InvoiceNum
            , '' AS [Merchant DateDue] --NG20240119
            , '' AS BillItemNumber --KMH20240221
            , '' AS Non_Commissioned_Reason --KMH20240221
            , '' AS UniqueID --KMH20240221
        FROM #Data2 AS d2
        WHERE d2.Cost < 0;
        --
        --------------------------------------------------------------------------------------------------------------
        -- Report
        --------------------------------------------------------------------------------------------------------------
        SELECT
            r.Account_ID
            , r.Account_Name
            , r.Address1 --NG20240119
            , r.Address2 --NG20240119
            , r.City --NG20240119
            , r.State --NG20240119
            , r.Zip --NG20240119
            , r.DateOrdered
            , r.DateFilled
            , r.Product
            , r.Description
            , r.IsPort
            , r.[Time (EST)]
            , r.OrderNo
            , r.ReferenceOrderNo
            , r.[User Name]
            , r.SIM
            , r.ESN
            , r.Phone
            , r.MAInvoiceNumber       -- DJJ20230517
            , r.Commission_Amt        -- DJJ20230517
            , r.[MA DateDue]               -- DJJ20230517
            , r.MerchantInvoiceNumber -- DJJ20230517
            , r.[Merchant DateDue] --NG20240119
            , r.Retail
            , r.Discount
            , r.Cost
            , r.Master_AccountID --BS20231102
            , r.Master_AccountName --BS20231102
            , r.[Payment Status] --KMH20231222
            , r.BillItemNumber --KMH20240221
            , r.Non_Commissioned_Reason --KMH20240221
            , r.UniqueID
        FROM #Results AS r
        ORDER BY r.OrderNo DESC;
        --
        --------------------------------------------------------------------------------------------------------------
        -- Cleanup
        --------------------------------------------------------------------------------------------------------------
        --DROP TABLE IF EXISTS #Data2;
        --DROP TABLE IF EXISTS #Data;
        --DROP TABLE IF EXISTS #OiA;
        --DROP TABLE IF EXISTS #Results;
        --DROP TABLE IF EXISTS #ListOfAccounts;
        --DROP TABLE IF EXISTS #ListOfCommInfo;
        --DROP TABLE IF EXISTS #OIA2;
        --DROP TABLE IF EXISTS #OrderAuth;
        --DROP TABLE IF EXISTS #OrderNo;
    --------------------------------------------------------------------------------------------------------------
    END TRY
    BEGIN CATCH

        SELECT
            ERROR_NUMBER() AS ErrorNumber
            , ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;
END;
